--- tests/unit/ui/menu/structure/test_tray_rows_read_as_text.lua

--- ==============================================================================
--- MODULE: The Linux Tray Reads As Text
--- DESCRIPTION:
--- Builds the tray through the real ui.menu.builder over the real French and
--- English catalogues, and fails on a row showing an id, a config path, a raw
--- key, snake_case or an unfilled placeholder (test.menu_row_text). A key no
--- catalogue holds comes back as itself here, as it does in the driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local check = require("test.menu_row_text")

local SHARED_ROOT = "../_shared"
-- The whole tray holds many more; fewer means a builder gave up.
local MIN_ROWS = 100

--- Builds the tray with one real catalogue behind i18n.
--- @param locale string Locale code.
--- @return table Rendered rows.
local function tray(locale)
	local decode = require("json").decode
	local catalogue = check.catalogue(SHARED_ROOT, locale, decode)
	local i18n = require("infra.i18n")
	local previous = i18n.get
	i18n.get = function(key)
		local text = catalogue[key]
		return (text == nil or text == "") and key or text
	end
	local ok, rows = pcall(function()
		return helpers.load_module("ui.menu.builder").build({
			_version = "9.9.9",
			config = { get_groups = function() return {} end },
		})
	end)
	i18n.get = previous
	helpers.assert_true(ok, "the tray must build: " .. tostring(rows))
	return rows
end

helpers.describe("the real Linux tray reads as text", function()
	helpers.it("the walk itself refuses each shape of raw text", function()
		local rows = { { title = "Disposition", menu = {
			{ title = "on_pause" }, { title = "menu.layout.layout_on_pause" },
			{ title = "some_raw_id" }, { title = "Layout {1}" }, { title = "Disposition" },
		} } }
		local defects = check.defects(rows, SHARED_ROOT, require("json").decode)
		helpers.assert_eq(#defects, 4, "only the plain label may pass: " .. table.concat(defects, " | "))
	end)

	helpers.it("the walk refuses a French row that glues its punctuation", function()
		helpers.assert_eq(check.french_punctuation_defect("Délai: 100"), "Délai:")
		helpers.assert_eq(check.french_punctuation_defect("Vraiment?"), "Vraiment?")
		helpers.assert_eq(check.french_punctuation_defect("Délai : 100"), nil)
		helpers.assert_eq(check.french_punctuation_defect("Voir https://ergopti.fr"), nil)
	end)

	helpers.it("reaches every French submenu row joining a label to its value", function()
		local decode = require("json").decode
		local catalogue = check.catalogue(SHARED_ROOT, "fr", decode)
		helpers.assert_eq(check.missing_label_value_rows(tray("fr"), SHARED_ROOT, decode, catalogue, "linux"), {})
	end)

	for _, locale in ipairs({ "fr", "en" }) do
		helpers.it("shows no raw id in " .. locale, function()
			local defects, rows = check.defects(tray(locale), SHARED_ROOT, require("json").decode, locale)
			helpers.assert_true(rows >= MIN_ROWS, "the walk stopped early at " .. rows .. " rows")
			helpers.assert_eq(defects, {}, "a row must read as text")
		end)
	end
end)
